import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const syncScriptPath = path.join(repositoryRoot, "scripts/tatwo-device-sync.sh");

function shellFunction(source, name, nextName) {
  const startMarker = `${name}() {`;
  const endMarker = `\n${nextName}() {`;
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.notEqual(start, -1, `${name} function is missing`);
  assert.notEqual(end, -1, `${nextName} function boundary is missing`);
  return source.slice(start, end);
}

function assertEveryRefreshFailureReturns(refresh) {
  const lines = refresh.split("\n");
  let callCount = 0;

  for (let index = 0; index < lines.length; index += 1) {
    if (!lines[index].includes("fail_skillet_source_refresh_attempt \\")) {
      continue;
    }
    callCount += 1;
    while (index < lines.length && lines[index].trimEnd().endsWith("\\")) {
      index += 1;
    }
    let nextCommand = index + 1;
    while (
      nextCommand < lines.length &&
      (lines[nextCommand].trim() === "" ||
        lines[nextCommand].trimStart().startsWith("#"))
    ) {
      nextCommand += 1;
    }
    assert.equal(
      lines[nextCommand]?.trim(),
      "return 1",
      `source refresh failure at line ${index + 1} must immediately return 1`
    );
  }

  assert.ok(callCount > 0, "source refresh must retain at least one fail-closed guard");
}

test("every source refresh failure call immediately returns 1", () => {
  const source = fs.readFileSync(syncScriptPath, "utf8");
  const refresh = shellFunction(
    source,
    "refresh_canonical_skillet_sources",
    "prepare_system_payload"
  );

  assertEveryRefreshFailureReturns(refresh);

  const missingReturn = refresh.replace(
    /(\s+fail_skillet_source_refresh_attempt \\\n(?:.*\\\n)*.*\n)\s+return 1/,
    "$1"
  );
  assert.throws(
    () => assertEveryRefreshFailureReturns(missingReturn),
    /must immediately return 1/
  );
});

test("system payload preparation explicitly blocks publication when refresh fails", () => {
  const source = fs.readFileSync(syncScriptPath, "utf8");
  const prepare = shellFunction(source, "prepare_system_payload", "cmd_sync_request");

  assert.match(
    prepare,
    /refresh_canonical_skillet_sources \\\n(?:.*\\\n)+.*\\\n\s+\|\| die "Skillet canonical source refresh failed; request publication blocked"/
  );
});
