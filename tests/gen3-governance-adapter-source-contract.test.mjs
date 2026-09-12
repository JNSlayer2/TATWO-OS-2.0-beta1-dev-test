import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
const root = process.cwd();
const adapterPath = path.join(root, "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/Gen3GovernanceAdapters.swift");
const source = fs.readFileSync(adapterPath, "utf8");

test("Gen3 governance adapters wrap existing authority planes", () => {
  assert.match(source, /protocol RunAdmissionPolicy/);
  assert.match(source, /protocol ToolAuthorizationPolicy/);
  assert.match(source, /protocol CompletionJudge/);
  assert.match(source, /transaction\.begin\(contract: contract, owner: owner\)/);
  assert.match(source, /issuer\.authorizationID\(for: request\)/);
  assert.match(source, /WorkOSFactory\.closeGoal/);
});

test("approval prose cannot mint authorization", () => {
  assert.doesNotMatch(source, /已批准|approved\s*=\s*true/i);
  assert.doesNotMatch(source, /TatwoHostOperationAuthorizationV1\s*\(/);
});

test("no second authorization issuer entrypoint exists", () => {
  const files = fs.readdirSync(path.dirname(adapterPath)).filter(f => f.endsWith(".swift"));
  const declarations = files.flatMap(f => [...fs.readFileSync(path.join(path.dirname(adapterPath), f), "utf8").matchAll(/struct\s+(\w*HostOperationAuthorizationIssuer\w*)/g)].map(m => `${f}:${m[1]}`));
  assert.deepEqual(declarations, ["ChatNativeAgentRunner.swift:ChatNativeHostOperationAuthorizationIssuer"]);
});

test("admission has no staging write outside atomic GoalAuthorityTransaction", () => {
  const body = source.slice(source.indexOf("struct ExistingGoalAuthorityAdmissionAdapter"), source.indexOf("struct ExistingHostOperationAuthorizationAdapter"));
  assert.doesNotMatch(body, /write|createDirectory|Data\(contentsOf|FileManager/);
  assert.match(body, /transaction\.begin/);
});
