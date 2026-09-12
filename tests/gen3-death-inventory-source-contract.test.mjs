import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
// NativePaneSessionCore.swift was split by top-level type (2026-09-02); the
// contract now covers every Core source file.
const coreDir = "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore";
const core = fs
  .readdirSync(coreDir)
  .filter((name) => name.endsWith(".swift"))
  .sort()
  .map((name) => fs.readFileSync(`${coreDir}/${name}`, "utf8"))
  .join("\n");
const continuation = fs.readFileSync("Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GatewayConversationContinuation.swift", "utf8");
const inventory = fs.readFileSync("docs/plans/GEN3_DEATH_INVENTORY.md", "utf8");

test("gatewayDirect has no production route profile", () => {
  const declarations = [...core.matchAll(/runtimeAdapter: \.gatewayDirect/g)];
  assert.equal(declarations.length, 1, "only historical command construction may mention gatewayDirect");
});

test("gatewayDirect historical decode remains available", () => {
  assert.match(core, /case gatewayDirect = "gateway-direct"/);
  assert.match(core, /runtimeAdapter = try container\.decode/);
  assert.match(continuation, /TatwoChatRuntimeAdapter\.gatewayDirect\.rawValue/);
});

test("inventory carries all three evidence columns and forbids deletion", () => {
  assert.match(inventory, /Production call graph/);
  assert.match(inventory, /Fixture decode dependency/);
  assert.match(inventory, /Durable-state dependency/);
  assert.match(inventory, /No code is deleted in K3/);
  assert.match(inventory, /nativeAgent[\s\S]*Live runtime route/);
  assert.match(inventory, /production-default UI-event read path/);
  assert.match(inventory, /Deprecated, rollback-only; do not delete/);
  assert.match(inventory, /TATWO_USE_LEGACY_VENDOR_EVENT_PARSER=1/);
});
