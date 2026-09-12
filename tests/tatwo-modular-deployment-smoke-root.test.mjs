import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const smokeScript = path.join(
  repoRoot,
  "scripts",
  "tatwo-modular-deployment-smoke.mjs",
);

test("creates a unique run directory when the sandbox parent does not exist", () => {
  const fixtureRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), "tatwo-modular-smoke-root-"),
  );
  const missingSandboxParent = path.join(fixtureRoot, "missing", "sandbox");

  assert.equal(fs.existsSync(missingSandboxParent), false);

  for (let attempt = 0; attempt < 2; attempt += 1) {
    const result = spawnSync(process.execPath, [
      smokeScript,
      "--binary",
      process.execPath,
      "--sandbox-root",
      missingSandboxParent,
    ], {
      cwd: repoRoot,
      encoding: "utf8",
    });

    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.stderr, /ENOENT.*mkdir/s);
    assert.match(result.stderr, /command failed/);
  }

  const runDirectories = fs.readdirSync(missingSandboxParent, {
    withFileTypes: true,
  }).filter((entry) => entry.isDirectory() && entry.name.startsWith("run-"));

  assert.equal(runDirectories.length, 2);
  assert.notEqual(runDirectories[0].name, runDirectories[1].name);
});
