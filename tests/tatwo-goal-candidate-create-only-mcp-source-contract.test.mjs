#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scriptPath = path.join(repoRoot, "scripts", "tatwo-ultrawork-mcp.mjs");
const source = fs.readFileSync(scriptPath, "utf8");

test("Node MCP executable selftest exposes and forwards the exact candidate artifact", () => {
  const result = spawnSync(process.execPath, [scriptPath, "--selftest"], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const payload = JSON.parse(result.stdout);
  assert.equal(payload.ok, true);
  const checks = new Map(payload.checks.map(check => [check.id, check]));
  for (const id of [
    "tool.goal.candidate.create.exists",
    "tool.goal.candidate.create.requires-exact-artifact",
    "tool.goal.candidate.create.routes-to-swift-mcp-call",
    "tool.goal.candidate.create.preserves-exact-request-strings",
  ]) {
    assert.equal(checks.get(id)?.ok, true, JSON.stringify(checks.get(id)));
  }
});

test("Node MCP source keeps the candidate route create-only and closed-schema", () => {
  const toolDefinition = source.match(
    /name:\s*"tatwo_os_goal_candidate_create"[\s\S]*?additionalProperties:\s*false[\s\S]*?\n\s*}\n\s*},/)?.[0] ?? "";
  assert.ok(toolDefinition, "candidate tool definition must remain discoverable");
  for (const required of [
    "mode",
    "scenario",
    "objective",
    "authorizationBindingArtifactSHA256",
    "authorizationBindingArtifactJSON",
  ]) {
    assert.match(toolDefinition, new RegExp(`"${required}"`));
  }
  assert.match(
    source,
    /case "tatwo_os_goal_candidate_create":[\s\S]*?"mcp",\s*"call",\s*"tatwo\.os\.goal\.candidate\.create"[\s\S]*?"--arguments"/);
  assert.doesNotMatch(
    toolDefinition,
    /artifactPath|authorizationPath|filePath/,
    "authorization must be exact request data, never a path");
});
