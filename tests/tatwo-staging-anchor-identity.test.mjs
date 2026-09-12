import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const resolver = path.join(
  repoRoot,
  "script",
  "tatwo-staging-anchor-identity.py",
);

function resolveIdentity(runtimeRoot, stamp, token, environment = {}) {
  const result = spawnSync(
    "/usr/bin/python3",
    [
      resolver,
      "--runtime-root",
      runtimeRoot,
      "--stamp",
      stamp,
      "--token",
      token,
    ],
    {
      encoding: "utf8",
      env: { ...process.env, ...environment },
    },
  );
  assert.equal(
    result.status,
    0,
    `resolver failed: ${result.stderr || result.stdout}`,
  );
  const [service, account] = result.stdout.trim().split("\t");
  return { service, account };
}

test("rebuilding the same staging runtime preserves its PLG anchor identity", () => {
  const runtimeRoot = mkdtempSync(
    path.join(tmpdir(), "tatwo-staging-anchor-same-root-"),
  );

  const first = resolveIdentity(
    runtimeRoot,
    "20260818T010000Z",
    "11111111-1111-4111-8111-111111111111",
  );
  const rebuilt = resolveIdentity(
    runtimeRoot,
    "20260818T020000Z",
    "22222222-2222-4222-8222-222222222222",
  );

  assert.deepEqual(first, {
    service:
      "ai.tatwo.ultrawork.plg-chain-anchor.staging.20260818T010000Z.11111111-1111-4111-8111-111111111111",
    account:
      "staging.20260818T010000Z.11111111-1111-4111-8111-111111111111",
  });
  assert.deepEqual(rebuilt, first);

  const identityPath = path.join(
    runtimeRoot,
    "plg-anchor-identity-v1.json",
  );
  const persisted = JSON.parse(readFileSync(identityPath, "utf8"));
  assert.equal(persisted.schema, "TatwoStagingPLGAnchorIdentityV1");
  assert.equal(persisted.service, first.service);
  assert.equal(persisted.account, first.account);
  assert.equal(statSync(identityPath).mode & 0o777, 0o600);
});

test("different staging runtime roots receive different PLG anchor identities", () => {
  const firstRoot = mkdtempSync(
    path.join(tmpdir(), "tatwo-staging-anchor-first-root-"),
  );
  const secondRoot = mkdtempSync(
    path.join(tmpdir(), "tatwo-staging-anchor-second-root-"),
  );

  const first = resolveIdentity(
    firstRoot,
    "20260818T030000Z",
    "33333333-3333-4333-8333-333333333333",
  );
  const second = resolveIdentity(
    secondRoot,
    "20260818T040000Z",
    "44444444-4444-4444-8444-444444444444",
  );

  assert.notDeepEqual(second, first);
});

test("an existing staging runtime can pin its previously issued anchor identity", () => {
  const runtimeRoot = mkdtempSync(
    path.join(tmpdir(), "tatwo-staging-anchor-migration-"),
  );
  const previous = {
    service:
      "ai.tatwo.ultrawork.plg-chain-anchor.staging.20260817T202619Z.e96f33d9-ffc7-46bf-b6b8-427fe20c06db",
    account:
      "staging.20260817T202619Z.e96f33d9-ffc7-46bf-b6b8-427fe20c06db",
  };

  const migrated = resolveIdentity(
    runtimeRoot,
    "20260818T050000Z",
    "55555555-5555-4555-8555-555555555555",
    {
      TATWO_STAGING_PLG_ANCHOR_SERVICE: previous.service,
      TATWO_STAGING_PLG_ANCHOR_ACCOUNT: previous.account,
    },
  );
  const rebuilt = resolveIdentity(
    runtimeRoot,
    "20260818T060000Z",
    "66666666-6666-4666-8666-666666666666",
  );

  assert.deepEqual(migrated, previous);
  assert.deepEqual(rebuilt, previous);
});
