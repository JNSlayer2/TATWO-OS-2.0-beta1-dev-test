#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = relativePath =>
  fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
// ChatPageModel.swift was split into topic files (2026-09-02); read the family.
const readChatPageModelFamily = () => {
  const dir = path.join(repoRoot, "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac");
  return fs.readdirSync(dir)
    .filter(name => name === "ChatPageModel.swift" || name.startsWith("ChatPageModel+"))
    .sort()
    .map(name => fs.readFileSync(path.join(dir, name), "utf8"))
    .join("\n");
};

test("GoalRun live surfaces share the canonical Tatwo Ultrawork state root", () => {
  const goalRunStore = read(
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalRunStore.swift");
  const runtimeLayout = read(
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoRuntimeLayout.swift");
  const app = readChatPageModelFamily();
  const mcpFramework = read(
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/MCPFramework.swift");
  const cli = read(
    "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift");
  const nodeMCP = read("scripts/tatwo-ultrawork-mcp.mjs");

  assert.match(
    runtimeLayout,
    /applicationSupportDirectoryName\s*=\s*"Tatwo Ultrawork"/);
  assert.match(
    runtimeLayout,
    /stateRoot[\s\S]*applicationSupportRoot[\s\S]*appendingPathComponent\("state"/);

  const defaultStoreBody = goalRunStore.match(
    /public static func `default`[\s\S]*?\n  }\n\n  \/\//)?.[0] ?? "";
  assert.ok(defaultStoreBody, "TatwoGoalRunStore.default body must remain discoverable");
  assert.match(defaultStoreBody, /TATWO_ULTRAWORK_STATE_DIR/);
  assert.match(defaultStoreBody, /TATWO_ULTRAWORK_APP_SUPPORT/);
  assert.match(defaultStoreBody, /appendingPathComponent\("state"/);
  assert.match(defaultStoreBody, /implicitDefaultDirectory\(environment: environment\)/);
  assert.match(
    goalRunStore,
    /static func implicitDefaultDirectory\([\s\S]*?TatwoRuntimeLayout\.stateRoot\(/);
  assert.doesNotMatch(
    defaultStoreBody,
    /TATWO_OS_ROOT|swift-workos/,
    "TATWO_OS_ROOT is an adapter/constitution root, not GoalRun authority");

  assert.match(
    app,
    /TatwoGoalRunStore\.default\(environment: environment\)/);
  assert.match(mcpFramework, /TatwoGoalRunStore\.default\(\)/);
  assert.match(cli, /TatwoGoalRunStore\.default\(\)/);

  const nodeStateResolver = nodeMCP.match(
    /function workOSStateDirectory\(\)[\s\S]*?\n}\n/)?.[0] ?? "";
  assert.ok(nodeStateResolver, "Node MCP state resolver must remain discoverable");
  assert.match(
    nodeStateResolver,
    /"Application Support",\s*"Tatwo Ultrawork",\s*"state"/);
  assert.doesNotMatch(
    nodeStateResolver,
    /state",\s*"swift-workos"/,
    "Node MCP must not revive the historical TATWO_OS_ROOT state fork");
  assert.match(
    goalRunStore,
    /canonicalStateRootIfKnownLegacy[\s\S]*?"TatwoUltrawork"[\s\S]*?"Tatwo Ultrawork"/,
    "Swift GoalRun store must normalize the one known no-space legacy root");
  assert.match(
    nodeMCP,
    /canonicalWorkOSStateDirectory[\s\S]*?"TatwoUltrawork"[\s\S]*?"Tatwo Ultrawork"/,
    "Node MCP must normalize the one known no-space legacy root");
  assert.match(
    goalRunStore,
    /guard candidate\.standardizedFileURL == legacy else \{\s*return candidate\s*\}/,
    "Swift normalization must preserve arbitrary explicit roots");
  assert.match(
    nodeMCP,
    /path\.resolve\(candidate\) !== path\.resolve\(legacy\)\) return candidate/,
    "Node normalization must preserve arbitrary explicit roots");

  assert.match(
    nodeMCP,
    /name:\s*"tatwo_os_session_attach"[\s\S]*?never calls tatwo_os_begin/,
    "Node MCP must expose an explicit current-session attach path");
  assert.match(
    nodeMCP,
    /case "tatwo_os_session_attach":[\s\S]*?\["os", "session", "attach", "--json"\][\s\S]*?appendOption\(out, "--provider", args\.provider\)[\s\S]*?appendOption\(out, "--owner-session", args\.ownerSession\)[\s\S]*?appendOption\(out, "--owner-thread", args\.ownerThread\)[\s\S]*?appendOption\(out, "--workspace", args\.workspace\)/,
    "Node MCP attach must preserve the exact owner kind through the read-only Swift CLI session attachment");
  const attachInput = nodeMCP.match(
    /const currentSessionAttachInput = \{[\s\S]*?\n\};/)?.[0] ?? "";
  assert.ok(attachInput, "Node MCP attach input schema must remain discoverable");
  assert.match(attachInput, /required: \["provider", "workspace"\]/);
  assert.match(attachInput, /oneOf:[\s\S]*?ownerSession[\s\S]*?ownerThread/);
  assert.match(attachInput, /additionalProperties: false/);
  const beginTool = nodeMCP.match(
    /name:\s*"tatwo_os_begin"[\s\S]*?inputSchema:\s*formalWorkOSBeginInput/)?.[0] ?? "";
  assert.ok(beginTool, "Node MCP begin tool must remain discoverable");
  const beginInput = nodeMCP.match(
    /const formalWorkOSBeginInput = \{[\s\S]*?\n\};/)?.[0] ?? "";
  assert.ok(beginInput, "Node MCP begin input schema must remain discoverable");
  assert.doesNotMatch(
    beginInput,
    /\b(?:contractID|goalID)\s*:/,
    "tatwo_os_begin must not advertise existing IDs that its handler ignores");
  assert.match(
    beginInput,
    /enum:\s*\["S", "M", "L", "XL", "XXL"\]/,
    "Node MCP Work OS entry schemas must allow XXL");

  for (const [name, source] of [
    ["GoalRunStore", goalRunStore],
    ["App", app],
    ["MCPFramework", mcpFramework],
    ["CLI", cli],
    ["Node MCP", nodeMCP],
  ]) {
    assert.doesNotMatch(
      source,
      /Application Support[\/\\]TatwoUltrawork/,
      `${name} must not write to the no-space legacy root`);
  }
});

test("same-thread loops refresh preserves contracts across presentation-only differences", () => {
  const app = readChatPageModelFamily();
  const reusePolicy = app.match(
    /static func canReuseIssuedContract\([\s\S]*?\n    }\n\n    (?:private )?func workOSRouteBindingOverride/)?.[0] ?? "";

  assert.ok(reusePolicy, "same-thread GoalRun reuse policy must remain discoverable");
  assert.match(reusePolicy, /previous\.scenarioID == next\.scenarioID/);
  assert.match(reusePolicy, /previous\.mode == next\.mode/);
  assert.match(reusePolicy, /WorkOSRouteBindingOverride/);
  assert.doesNotMatch(
    reusePolicy,
    /identitySummary|tokenBudget|return next == previous/,
    "presentation and ephemeral labels must not invalidate the canonical GoalRun binding");
});
